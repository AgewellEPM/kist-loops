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

    public init(taskSignature: String, taskTags: [String], language: String?, role: String,
                providerId: String, model: String?, source: CaptainLearningSource,
                success: Bool, judgeScore: Double? = nil, tokens: Int = 0,
                latencyMs: Int = 0, toolFailures: Int = 0, atEpoch: Double) {
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
