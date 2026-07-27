import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A durable lesson the runtime learned from a past run: a PROVEN win (verified success) or an
/// OBSTACLE (a failure to avoid repeating). Memory is RETRIEVAL ONLY — a lesson is advisory context
/// injected into briefs, never a verdict authority. Invariant (honesty): a lesson can only be `.proven`
/// if it has a `source` (a real signoff/run it came from); a sourceless "proven" is coerced to obstacle.
public struct Lesson: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable { case proven, obstacle }
    public let id: String
    public let kind: Kind
    public let text: String
    public let keywords: [String]
    public let source: String?       // e.g. a signoff seq / run id — required for `.proven`
    public let at: Double            // epoch seconds (injected; never Date() here)

    public init(kind: Kind, text: String, source: String?, at: Double, keywords: [String]? = nil) {
        // Honesty coercion: no source ⇒ cannot claim "proven".
        let effectiveKind: Kind = (kind == .proven && (source?.isEmpty ?? true)) ? .obstacle : kind
        let safeText = Self.redactForStorage(text)
        self.kind = effectiveKind
        self.text = safeText
        self.source = source
        self.at = at
        self.keywords = keywords ?? Lesson.extractKeywords(safeText)
        self.id = "\(effectiveKind.rawValue):\(source ?? "-"):\(Self.stableHash(safeText))"
    }

    // Custom decode so a hand-written / tampered lessons.jsonl can't smuggle in a sourceless `.proven`:
    // route every decoded lesson through the invariant-enforcing initializer (which coerces it to
    // `.obstacle`). Synthesized Codable would otherwise set `kind` directly and bypass the honesty rule.
    private enum CodingKeys: String, CodingKey { case id, kind, text, keywords, source, at }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try c.decode(Kind.self, forKey: .kind),
                  text: try c.decode(String.self, forKey: .text),
                  source: try c.decodeIfPresent(String.self, forKey: .source),
                  at: try c.decode(Double.self, forKey: .at),
                  keywords: try c.decodeIfPresent([String].self, forKey: .keywords))
    }

    static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "to", "of", "in", "on", "for", "is", "are", "was",
        "be", "with", "that", "this", "it", "as", "at", "by", "from", "we", "you", "i", "if", "so", "do"
    ]

    public static func extractKeywords(_ text: String) -> [String] {
        let tokens = text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
        var seen = Set<String>(); var out: [String] = []
        for t in tokens where t.count > 2 && !stopwords.contains(t) {
            if seen.insert(t).inserted { out.append(t) }
        }
        return out
    }

    public static func redactForStorage(_ text: String) -> String {
        var safe = SecretScanner.redactSecrets(in: text)
        let home = NSHomeDirectory()
        if !home.isEmpty {
            safe = safe.replacingOccurrences(of: home, with: "~")
        }
        return safe
    }

    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

/// Append-only, capacity-bounded lesson store with keyword-ranked retrieval. Mirrors OutcomeMemory:
/// a signoff ⇒ proven lesson, a rejection ⇒ obstacle. Cross-fleet learning, advisory only.
public struct LessonStore: Sendable {
    private let path: String
    private let capacity: Int

    public init(path: String = NSHomeDirectory() + "/.mythos/lessons.jsonl", capacity: Int = 2000) {
        self.path = path; self.capacity = capacity
    }

    public func all() -> [Lesson] {
        withFileLock { readAll() }
    }

    private func readAll() -> [Lesson] {
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONDecoder().decode(Lesson.self, from: Data($0.utf8))
        }
    }

    public func record(_ lesson: Lesson) {
        withFileLock {
            var lessons = readAll()
            guard !lessons.contains(where: { $0.id == lesson.id }) else { return }   // dedupe
            lessons.append(lesson)
            if lessons.count > capacity { lessons = Array(lessons.suffix(capacity)) }
            write(lessons)
        }
    }

    /// Top lessons relevant to a goal, keyword-ranked. Obstacles weigh slightly higher (a warning you
    /// ignore costs more than a tip you miss); ties break toward more recent.
    public func retrieve(forGoal goal: String, limit: Int = 5) -> [Lesson] {
        let q = Set(Lesson.extractKeywords(goal))
        guard !q.isEmpty else { return [] }
        func score(_ l: Lesson) -> Double {
            let hits = l.keywords.reduce(0) { $0 + (q.contains($1) ? 1 : 0) }
            let weight = l.kind == .obstacle ? 1.2 : 1.0
            return Double(hits) * weight
        }
        var scored: [(lesson: Lesson, score: Double)] = []
        for l in all() {
            let s = score(l)
            if s > 0 { scored.append((l, s)) }
        }
        scored.sort { a, b in a.score != b.score ? a.score > b.score : a.lesson.at > b.lesson.at }
        return scored.prefix(limit).map { $0.lesson }
    }

    /// A compact primer for injection into an agent brief (advisory context, clearly labeled).
    public func primer(forGoal goal: String, limit: Int = 5) -> String? {
        let hits = retrieve(forGoal: goal, limit: limit)
        guard !hits.isEmpty else { return nil }
        let lines = hits.map { ($0.kind == .proven ? "✓ proven: " : "⚠ obstacle: ") + $0.text }
        return "LESSONS FROM PAST RUNS (advisory — verify, don't assume):\n" + lines.joined(separator: "\n")
    }

    private func write(_ lessons: [Lesson]) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let body = lessons.compactMap { try? JSONEncoder().encode($0) }
            .map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
        try? body.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func withFileLock<T>(_ body: () -> T) -> T {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let lockPath = path + ".lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return body() }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        flock(fd, LOCK_EX)
        return body()
    }
}
