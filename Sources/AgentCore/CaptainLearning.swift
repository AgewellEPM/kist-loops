import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
    /// Retained as labeled audit data, excluded from performance routing. A denied
    /// action is not evidence that another model should be selected to perform it.
    public static let refusalOrPermissionStopReason = "refusalOrPermissionStop"

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
        self.taskTags = Array(Set(taskTags.map(Self.canonicalDimension).filter { !$0.isEmpty })).sorted()
        self.language = language.map(Self.canonicalDimension).flatMap { $0.isEmpty ? nil : $0 }
        self.role = Self.canonicalDimension(role)
        self.providerId = Self.canonicalDimension(providerId)
        self.model = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.source = source
        self.success = success
        self.judgeScore = judgeScore.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        self.tokens = max(0, tokens)
        self.latencyMs = max(0, latencyMs)
        self.toolFailures = max(0, toolFailures)
        self.atEpoch = atEpoch
        self.failureReason = failureReason?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.failedAt = failedAt?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.loopKinds = loopKinds
        self.wasStuck = wasStuck
        self.failureRate = failureRate.isFinite ? min(1, max(0, failureRate)) : 0
    }

    /// Backward-compatible decode: old JSONL lines lack the failure/loop fields → default them, so the
    /// whole (already-populated) store still reads instead of throwing and coming back empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            taskSignature: try c.decode(String.self, forKey: .taskSignature),
            taskTags: try c.decode([String].self, forKey: .taskTags),
            language: try c.decodeIfPresent(String.self, forKey: .language),
            role: try c.decode(String.self, forKey: .role),
            providerId: try c.decode(String.self, forKey: .providerId),
            model: try c.decodeIfPresent(String.self, forKey: .model),
            source: try c.decode(CaptainLearningSource.self, forKey: .source),
            success: try c.decode(Bool.self, forKey: .success),
            judgeScore: try c.decodeIfPresent(Double.self, forKey: .judgeScore),
            tokens: try c.decodeIfPresent(Int.self, forKey: .tokens) ?? 0,
            latencyMs: try c.decodeIfPresent(Int.self, forKey: .latencyMs) ?? 0,
            toolFailures: try c.decodeIfPresent(Int.self, forKey: .toolFailures) ?? 0,
            atEpoch: try c.decode(Double.self, forKey: .atEpoch),
            failureReason: try c.decodeIfPresent(String.self, forKey: .failureReason),
            failedAt: try c.decodeIfPresent(String.self, forKey: .failedAt),
            loopKinds: try c.decodeIfPresent([String].self, forKey: .loopKinds) ?? [],
            wasStuck: try c.decodeIfPresent(Bool.self, forKey: .wasStuck) ?? false,
            failureRate: try c.decodeIfPresent(Double.self, forKey: .failureRate) ?? 0)
    }

    static func canonicalDimension(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
        let wantedTags = Set(taskTags.map(CaptainLearningSample.canonicalDimension))
        let role = CaptainLearningSample.canonicalDimension(role)
        let provider = CaptainLearningSample.canonicalDimension(providerId)
        let lang = language.map(CaptainLearningSample.canonicalDimension)
        let matches = summaries.filter { summary in
            summary.providerId == provider
                && summary.role == role
                && (!Set(summary.taskTags).isDisjoint(with: wantedTags))
                && (lang == nil || summary.language == lang || summary.language == nil)
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

/// One bounded temporal policy feeds both assignment summaries and provider verdicts. Samples are
/// advisory observations, not confirmation authority; no seasonal or verified state is inferred here.
public enum CaptainLearningRecencyPolicy {
    public static let maximumSamplesPerBucket = 20
    public static let maximumAgeSeconds: Double = 30 * 24 * 3_600
    public static let maximumFutureSkewSeconds: Double = 5 * 60
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
    public static let recencyWindow = CaptainLearningRecencyPolicy.maximumSamplesPerBucket
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
    /// Hard audit budgets are deliberately separate from the 30-day routing window. The JSONL remains
    /// unsigned advisory history, but reading it must never allocate in proportion to a hostile file.
    static let maximumFileBytes = 16 * 1_024 * 1_024
    static let maximumRowBytes = 64 * 1_024
    static let maximumRows = 20_000

    private struct BucketKey: Hashable {
        let role: String
        let providerId: String
        let tag: String
        let language: String?
    }

    private struct RetrievalBucketKey: Hashable {
        let role: String
        let providerId: String
        let language: String?
    }

    private struct IndexedSample {
        let offset: Int
        let sample: CaptainLearningSample
    }

    /// Audit reads may return independently valid rows from a damaged file. Mutation is admitted only
    /// for `missing` or `complete`, so fail-soft inspection can never become a destructive rewrite.
    private enum JSONLLoadResult {
        case missing
        case complete([CaptainLearningSample])
        case partial([CaptainLearningSample])
        case refused

        var auditRows: [CaptainLearningSample] {
            switch self {
            case .complete(let rows), .partial(let rows): return rows
            case .missing, .refused: return []
            }
        }

        var rowsForMutation: [CaptainLearningSample]? {
            switch self {
            case .missing: return []
            case .complete(let rows): return rows
            case .partial, .refused: return nil
            }
        }
    }

    private let path: String
    private let maxSamples: Int

    public init(projectRoot: String, maxSamples: Int = 5000) {
        self.path = projectRoot + "/" + Self.relativePath
        self.maxSamples = min(Self.maximumRows, max(100, maxSamples))
    }

    public func load() -> [CaptainLearningSample] {
        loadJSONLResult().auditRows
    }

    /// Return false when the existing archive cannot be proven safe to mutate. Callers may continue to
    /// treat this unsigned scorecard as advisory, but they can now distinguish a durable observation from
    /// a refused write when that distinction matters.
    @discardableResult
    public func record(_ sample: CaptainLearningSample) -> Bool {
        record([sample])
    }

    @discardableResult
    public func record(_ samples: [CaptainLearningSample]) -> Bool {
        guard !samples.isEmpty else { return true }
        return withMutationLock {
            guard var all = loadJSONLResult().rowsForMutation else { return false }
            all.append(contentsOf: samples)
            if all.count > maxSamples { all = Array(all.suffix(maxSamples)) }
            return persistUnlocked(all)
        } ?? false
    }

    public func assignmentContext(now: Double = Date().timeIntervalSince1970) -> ModelAssignmentLearningContext {
        ModelAssignmentLearningContext(summaries: Self.summarize(load(), now: now))
    }

    /// Per-model verdicts the escalator reads to steer toward strong models and away from failers/loopers.
    /// Keyed by lowercased providerId. `now` is injectable for tests.
    public func modelVerdicts(now: Double = Date().timeIntervalSince1970) -> [String: ModelVerdict] {
        Self.modelVerdicts(load(), now: now)
    }

    public static func modelVerdicts(_ samples: [CaptainLearningSample], now: Double) -> [String: ModelVerdict] {
        let eligible = routingEligibleSamples(samples, now: now)
        var byProvider: [String: [IndexedSample]] = [:]
        for indexed in eligible {
            byProvider[indexed.sample.providerId, default: []].append(indexed)
        }
        var out: [String: ModelVerdict] = [:]
        for (pid, all) in byProvider {
            out[pid] = makeVerdict(providerId: pid, samples: all, now: now)
        }
        return out
    }

    /// Deterministic per-model verdict over its recent runs. Cold-start neutral; chronic-exclude only;
    /// stale offenders get a probe. Pure (given `now`) so it is unit-testable without a clock.
    static func verdict(providerId: String, samples all: [CaptainLearningSample], now: Double) -> ModelVerdict {
        let provider = CaptainLearningSample.canonicalDimension(providerId)
        let eligible = routingEligibleSamples(all, now: now).filter { $0.sample.providerId == provider }
        return makeVerdict(providerId: provider, samples: eligible, now: now)
    }

    private static func makeVerdict(providerId: String, samples all: [IndexedSample],
                                    now: Double) -> ModelVerdict {
        // `all` is already the de-duplicated union of the shared, per-task-shape windows. Do not
        // re-window by provider here: that would silently discard eligible roles/tags.
        let recent = all.sorted(by: chronological)
        let n = recent.count
        let successes = recent.filter { $0.sample.success }.count
        let successRate = n == 0 ? 0 : Double(successes) / Double(n)
        let failureRate = n == 0 ? 0 : 1 - successRate
        let looped = recent.filter { !$0.sample.loopKinds.isEmpty || $0.sample.wasStuck }.count
        let loopRate = n == 0 ? 0 : Double(looped) / Double(n)
        var byReason: [String: Int] = [:]
        for indexed in recent {
            if let reason = indexed.sample.failureReason { byReason[reason, default: 0] += 1 }
        }
        let lastFailure = recent.filter { !$0.sample.success }.map { $0.sample.atEpoch }.max()

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

    public static func summarize(_ samples: [CaptainLearningSample],
                                 now: Double = Date().timeIntervalSince1970) -> [CaptainLearningSummary] {
        let summaries = routingBuckets(samples, now: now).map { key, values in
            makeSummary(role: key.role, providerId: key.providerId,
                        tags: [key.tag], language: key.language, values: values)
        }
        return sortSummaries(summaries)
    }

    /// Retrieval deliberately keeps one provider/role/language card while consuming the exact same
    /// finite, 30-day, future-skew, per-task-bucket survivor set as assignment and verdict routing.
    public static func summarizeForRetrieval(
        _ samples: [CaptainLearningSample],
        now: Double = Date().timeIntervalSince1970
    ) -> [CaptainLearningSummary] {
        var buckets: [RetrievalBucketKey: [IndexedSample]] = [:]
        for indexed in routingEligibleSamples(samples, now: now) {
            let sample = indexed.sample
            let key = RetrievalBucketKey(role: sample.role, providerId: sample.providerId,
                                         language: sample.language)
            buckets[key, default: []].append(indexed)
        }
        let summaries = buckets.map { key, allValues -> CaptainLearningSummary in
            // These are already shared per-task-bucket survivors, de-duplicated by append offset.
            let values = allValues.sorted(by: chronological)
            let tags = Array(Set(values.flatMap { sampleTags($0.sample) })).sorted()
            return makeSummary(role: key.role, providerId: key.providerId,
                               tags: tags, language: key.language, values: values)
        }
        return sortSummaries(summaries)
    }

    private static func routingBuckets(
        _ samples: [CaptainLearningSample], now: Double
    ) -> [BucketKey: [IndexedSample]] {
        guard now.isFinite else { return [:] }
        let oldest = now - CaptainLearningRecencyPolicy.maximumAgeSeconds
        var buckets: [BucketKey: [IndexedSample]] = [:]
        for (offset, sample) in samples.enumerated() {
            guard sample.failureReason != CaptainLearningSample.refusalOrPermissionStopReason else { continue }
            guard sample.atEpoch.isFinite,
                  sample.atEpoch >= oldest,
                  sample.atEpoch <= now + CaptainLearningRecencyPolicy.maximumFutureSkewSeconds,
                  !sample.providerId.isEmpty,
                  !sample.role.isEmpty else { continue }
            let indexed = IndexedSample(offset: offset, sample: sample)
            for tag in sampleTags(sample) {
                let key = BucketKey(role: sample.role, providerId: sample.providerId,
                                    tag: tag, language: sample.language)
                buckets[key, default: []].append(indexed)
            }
        }
        for key in Array(buckets.keys) {
            guard let values = buckets[key] else { continue }
            buckets[key] = Array(values.sorted(by: chronological)
                .suffix(CaptainLearningRecencyPolicy.maximumSamplesPerBucket))
        }
        return buckets
    }

    /// Union by append offset prevents a multi-tag sample from being counted more than once in a
    /// provider verdict or retrieval card after each task-shape bucket applies its own suffix cap.
    private static func routingEligibleSamples(
        _ samples: [CaptainLearningSample], now: Double
    ) -> [IndexedSample] {
        var selected: [Int: IndexedSample] = [:]
        for values in routingBuckets(samples, now: now).values {
            for value in values { selected[value.offset] = value }
        }
        return selected.values.sorted { $0.offset < $1.offset }
    }

    /// Internal deterministic seam used by regressions to prove every aggregate consumes the same
    /// physical JSONL rows; a multi-tag row appears once in this list.
    static func routingEligibleAppendOffsets(
        _ samples: [CaptainLearningSample], now: Double
    ) -> [Int] {
        routingEligibleSamples(samples, now: now).map(\.offset)
    }

    private static func sampleTags(_ sample: CaptainLearningSample) -> [String] {
        sample.taskTags.isEmpty ? ["coding"] : sample.taskTags
    }

    private static func chronological(_ lhs: IndexedSample, _ rhs: IndexedSample) -> Bool {
        if lhs.sample.atEpoch != rhs.sample.atEpoch {
            return lhs.sample.atEpoch < rhs.sample.atEpoch
        }
        return lhs.offset < rhs.offset
    }

    private static func makeSummary(role: String, providerId: String, tags: [String],
                                    language: String?, values: [IndexedSample]) -> CaptainLearningSummary {
        let samples = values.map(\.sample)
        let successes = samples.filter(\.success).count
        let scored = samples.compactMap(\.judgeScore)
        let avgScore = scored.isEmpty ? nil : scored.reduce(0, +) / Double(scored.count)
        return CaptainLearningSummary(
            role: role, providerId: providerId,
            taskTags: tags.isEmpty ? ["coding"] : tags,
            language: language, samples: samples.count, successes: successes,
            averageJudgeScore: avgScore,
            averageTokens: boundedAverage(samples.map(\.tokens)),
            averageLatencyMs: boundedAverage(samples.map(\.latencyMs)),
            toolFailures: saturatingSum(samples.map(\.toolFailures)),
            latestEpoch: samples.map(\.atEpoch).max() ?? 0)
    }

    private static func boundedAverage(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let total = values.reduce(0.0) { partial, value in
            let next = partial + Double(value)
            return next.isFinite ? next : Double.greatestFiniteMagnitude
        }
        let average = total / Double(values.count)
        guard average < Double(Int.max) else { return Int.max }
        return max(0, Int(average))
    }

    private static func saturatingSum(_ values: [Int]) -> Int {
        values.reduce(0) { partial, value in
            let (sum, overflow) = partial.addingReportingOverflow(value)
            return overflow ? Int.max : sum
        }
    }

    private static func sortSummaries(_ summaries: [CaptainLearningSummary]) -> [CaptainLearningSummary] {
        summaries.sorted { a, b in
            if a.promoted != b.promoted { return a.promoted && !b.promoted }
            if a.scoreBoost != b.scoreBoost { return a.scoreBoost > b.scoreBoost }
            if a.samples != b.samples { return a.samples > b.samples }
            if a.providerId != b.providerId { return a.providerId < b.providerId }
            if a.role != b.role { return a.role < b.role }
            if a.taskTags != b.taskTags {
                return a.taskTags.lexicographicallyPrecedes(b.taskTags)
            }
            return (a.language ?? "") < (b.language ?? "")
        }
    }

    /// Bounded, descriptor-based JSONL inspection. A malformed/oversized row remains visible as a
    /// partial audit state while neighboring valid rows can still be inspected. Missing terminal newline
    /// is treated as a torn tail for mutation purposes, though its valid row remains audit-readable.
    private func loadJSONLResult() -> JSONLLoadResult {
#if canImport(Darwin) || canImport(Glibc)
        var linkMetadata = stat()
        guard lstat(path, &linkMetadata) == 0 else {
            return errno == ENOENT ? .missing : .refused
        }
        guard (linkMetadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              linkMetadata.st_nlink == 1,
              linkMetadata.st_uid == geteuid(),
              linkMetadata.st_size >= 0,
              linkMetadata.st_size <= off_t(Self.maximumFileBytes) else { return .refused }

        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return .refused }
        defer { _ = close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              before.st_nlink == 1,
              before.st_uid == geteuid(),
              before.st_dev == linkMetadata.st_dev,
              before.st_ino == linkMetadata.st_ino,
              before.st_size >= 0,
              before.st_size <= off_t(Self.maximumFileBytes) else { return .refused }

        let data: Data
        do {
            data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
        } catch {
            return .refused
        }
        var after = stat()
        guard data.count <= Self.maximumFileBytes,
              data.count == Int(before.st_size),
              fstat(descriptor, &after) == 0,
              after.st_dev == before.st_dev,
              after.st_ino == before.st_ino,
              after.st_size == before.st_size,
              after.st_nlink == before.st_nlink else { return .refused }
#else
        guard let data = FileManager.default.contents(atPath: path),
              data.count <= Self.maximumFileBytes else { return .refused }
#endif

        if data.isEmpty { return .complete([]) }
        var rows: [CaptainLearningSample] = []
        rows.reserveCapacity(min(maxSamples, 1_024))
        var physicalRows = 0
        var incomplete = data.last != 0x0a
        let lines = data.split(separator: 0x0a, omittingEmptySubsequences: false)
        for (ordinal, line) in lines.enumerated() {
            if line.isEmpty, ordinal == lines.count - 1, data.last == 0x0a { continue }
            physicalRows += 1
            guard physicalRows <= Self.maximumRows else {
                incomplete = true
                break
            }
            guard !line.isEmpty,
                  line.count <= Self.maximumRowBytes,
                  let sample = try? JSONDecoder().decode(
                    CaptainLearningSample.self, from: Data(line)) else {
                incomplete = true
                continue
            }
            rows.append(sample)
        }
        if physicalRows > maxSamples { incomplete = true }
        return incomplete ? .partial(rows) : .complete(rows)
    }

    /// Encode and replace only after every row and aggregate byte budget succeeds. Until `rename(2)`,
    /// the durable JSONL inode is untouched, so any encoding/write/fsync failure preserves exact bytes.
    private func persistUnlocked(_ samples: [CaptainLearningSample]) -> Bool {
        guard samples.count <= maxSamples, samples.count <= Self.maximumRows else { return false }
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            return false
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var output = Data()
        for sample in samples {
            guard let row = try? encoder.encode(sample),
                  row.count <= Self.maximumRowBytes,
                  row.count + 1 <= Self.maximumFileBytes,
                  output.count <= Self.maximumFileBytes - row.count - 1 else { return false }
            output.append(row)
            output.append(0x0a)
        }

#if canImport(Darwin) || canImport(Glibc)
        let filename = (path as NSString).lastPathComponent
        let temporaryPath = dir + "/.\(filename).\(ProcessInfo.processInfo.globallyUniqueString).tmp"
        let descriptor = open(
            temporaryPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600))
        guard descriptor >= 0 else { return false }
        var removeTemporary = true
        defer {
            _ = close(descriptor)
            if removeTemporary { _ = unlink(temporaryPath) }
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_nlink == 1,
              metadata.st_uid == geteuid(),
              fchmod(descriptor, mode_t(0o600)) == 0 else { return false }
        let wrote = output.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return raw.count == 0 }
            var offset = 0
            while offset < raw.count {
                let count = write(descriptor, base.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard wrote, fsync(descriptor) == 0, rename(temporaryPath, path) == 0 else { return false }
        removeTemporary = false
        return true
#else
        do {
            try output.write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            return false
        }
#endif
    }

    /// The stable sidecar—not the destination inode, which atomic replacement changes—guards the full
    /// read/modify/replace transaction. Lock acquisition is fail-closed; an unsafe symlink, foreign owner,
    /// hard link, non-regular file, or failed flock never falls back to an unlocked mutation.
    private func withMutationLock<T>(_ body: () -> T) -> T? {
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            return nil
        }
#if canImport(Darwin) || canImport(Glibc)
        let lockPath = path + ".lock"
        let descriptor = open(
            lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { return nil }
        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_nlink == 1,
              metadata.st_uid == geteuid(),
              fchmod(descriptor, mode_t(0o600)) == 0,
              flock(descriptor, LOCK_EX) == 0 else { return nil }
        var lockedMetadata = stat()
        guard fstat(descriptor, &lockedMetadata) == 0,
              lockedMetadata.st_dev == metadata.st_dev,
              lockedMetadata.st_ino == metadata.st_ino,
              lockedMetadata.st_nlink == 1 else { return nil }
#endif
        return body()
    }
}
