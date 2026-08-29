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
    public static let maximumTextUTF8Bytes = 8 * 1_024
    public static let maximumSourceUTF8Bytes = 4 * 1_024
    public static let maximumKeywords = 64
    public static let maximumKeywordUTF8Bytes = 128
    public enum Kind: String, Sendable, Codable { case proven, obstacle }
    public let id: String
    public let kind: Kind
    public let text: String
    public let keywords: [String]
    public let source: String?       // e.g. a signoff seq / run id — required for `.proven`
    public let at: Double            // epoch seconds (injected; never Date() here)
    /// Optional on disk for backward compatibility. A source string is only a
    /// join locator; it never becomes confirmation authority or a recurrence.
    public let temporal: MemoryTemporalEnvelope?

    public init(kind: Kind, text: String, source: String?, at: Double,
                keywords: [String]? = nil,
                temporal: MemoryTemporalEnvelope? = nil) {
        let boundedSource = source.flatMap {
            $0.utf8.count <= Self.maximumSourceUTF8Bytes ? $0 : nil
        }
        // Honesty coercion: no source ⇒ cannot claim "proven".
        let effectiveKind: Kind = (
            kind == .proven && (boundedSource?.isEmpty ?? true)
        ) ? .obstacle : kind
        let safeText = Self.boundedUTF8(
            Self.redactForStorage(text), maximumBytes: Self.maximumTextUTF8Bytes)
        let rawKeywords = keywords ?? Lesson.extractKeywords(safeText)
        var seenKeywords = Set<String>()
        let safeKeywords = rawKeywords.compactMap { keyword -> String? in
            let bounded = Self.boundedUTF8(
                keyword, maximumBytes: Self.maximumKeywordUTF8Bytes)
            guard !bounded.isEmpty, seenKeywords.insert(bounded).inserted else { return nil }
            return bounded
        }.prefix(Self.maximumKeywords)
        self.kind = effectiveKind
        self.text = safeText
        self.source = boundedSource
        self.at = at
        self.keywords = Array(safeKeywords)
        self.id = "\(effectiveKind.rawValue):\(boundedSource ?? "-"):\(Self.stableHash(safeText))"
        self.temporal = temporal
    }

    // Custom decode so a hand-written / tampered lessons.jsonl can't smuggle in a sourceless `.proven`:
    // route every decoded lesson through the invariant-enforcing initializer (which coerces it to
    // `.obstacle`). Synthesized Codable would otherwise set `kind` directly and bypass the honesty rule.
    private enum CodingKeys: String, CodingKey {
        case id, kind, text, keywords, source, at, temporal
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try c.decode(Kind.self, forKey: .kind),
                  text: try c.decode(String.self, forKey: .text),
                  source: try c.decodeIfPresent(String.self, forKey: .source),
                  at: try c.decode(Double.self, forKey: .at),
                  keywords: try c.decodeIfPresent([String].self, forKey: .keywords),
                  temporal: try c.decodeIfPresent(
                    MemoryTemporalEnvelope.self, forKey: .temporal))
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

    private static func boundedUTF8(_ value: String, maximumBytes: Int) -> String {
        var output = String()
        output.reserveCapacity(min(value.utf8.count, maximumBytes))
        var used = 0
        for scalar in value.unicodeScalars {
            let fragment = String(scalar)
            let bytes = fragment.utf8.count
            guard used <= maximumBytes - bytes else { break }
            output += fragment
            used += bytes
        }
        return output
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
    static let maximumCapacity = 10_000
    static let maximumFileBytes = 8 * 1_024 * 1_024
    static let maximumRowBytes = 64 * 1_024

    struct TemporalLessonProjection: Sendable {
        let lesson: Lesson
        let physicalOrdinal: Int
        let salience: Double
    }

    private let path: String
    private let capacity: Int
    private let now: @Sendable () -> Date

    public init(path: String = NSHomeDirectory() + "/.mythos/lessons.jsonl",
                capacity: Int = 2000,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.path = path
        self.capacity = max(1, min(capacity, Self.maximumCapacity))
        self.now = now
    }

    public func all() -> [Lesson] {
        withFileLock { readAll() ?? [] }
    }

    private func readAll(strict: Bool = false) -> [Lesson]? {
        readAllWithOrdinals(strict: strict)?.map(\.lesson)
    }

    private func readAllWithOrdinals(
        strict: Bool = false
    ) -> [(lesson: Lesson, physicalOrdinal: Int)]? {
        guard let data = boundedLessonTail(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let firstRetainedOrdinal = max(0, lines.count - capacity)
        var rows: [(lesson: Lesson, physicalOrdinal: Int)] = []
        rows.reserveCapacity(min(capacity, lines.count))
        for (ordinal, line) in lines.enumerated().dropFirst(firstRetainedOrdinal) {
            guard !line.isEmpty else { continue }
            guard line.utf8.count <= Self.maximumRowBytes,
                  let lesson = try? JSONDecoder().decode(
                    Lesson.self, from: Data(line.utf8)) else {
                if strict { return nil }
                continue
            }
            rows.append((lesson, ordinal))
        }
        return rows
    }

    public func record(_ lesson: Lesson) {
        withFileLock {
            // Persist valid wire data even when its application window is in
            // the future; retrieval applies the captured-clock skew/lifecycle
            // gate. This mirrors ProjectMemory and keeps reads fail-closed
            // without turning a clock disagreement into destructive loss.
            guard let stored = Self.lessonWithTemporalMetadata(lesson) else { return }
            // Never reinterpret a read/parse failure as an empty archive and
            // rewrite it. An oversized but valid archive supplies a bounded,
            // row-aligned tail and is compacted deliberately on success.
            guard var lessons = readAll(strict: true) else { return }
            guard !lessons.contains(where: { $0.id == stored.id }) else { return }   // dedupe
            lessons.append(stored)
            if lessons.count > capacity { lessons = Array(lessons.suffix(capacity)) }
            _ = write(lessons)
        }
    }

    /// Top lessons relevant to a goal, keyword-ranked. Obstacles weigh slightly higher (a warning you
    /// ignore costs more than a tip you miss); ties break toward more recent.
    public func retrieve(forGoal goal: String, limit: Int = 5,
                         at instant: Date? = nil) -> [Lesson] {
        let q = Set(Lesson.extractKeywords(goal))
        guard !q.isEmpty, limit > 0 else { return [] }
        let capturedNow = instant ?? now()
        guard Self.isWireDate(capturedNow) else { return [] }
        func lexicalScore(_ l: Lesson) -> Double {
            let hits = l.keywords.reduce(0) { $0 + (q.contains($1) ? 1 : 0) }
            let weight = l.kind == .obstacle ? 1.2 : 1.0
            return Double(hits) * weight
        }
        var scored: [(projection: TemporalLessonProjection, score: Double)] = []
        for row in withFileLock({ readAllWithOrdinals() ?? [] }) {
            guard let projection = Self.temporalProjection(
                row.lesson, physicalOrdinal: row.physicalOrdinal,
                now: capturedNow) else { continue }
            let score = lexicalScore(projection.lesson) * projection.salience
            if score > 0 { scored.append((projection, score)) }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.projection.lesson.at != rhs.projection.lesson.at {
                return lhs.projection.lesson.at > rhs.projection.lesson.at
            }
            if lhs.projection.physicalOrdinal != rhs.projection.physicalOrdinal {
                return lhs.projection.physicalOrdinal > rhs.projection.physicalOrdinal
            }
            return lhs.projection.lesson.id < rhs.projection.lesson.id
        }
        return scored.prefix(limit).map(\.projection.lesson)
    }

    /// A compact primer for injection into an agent brief (advisory context, clearly labeled).
    public func primer(forGoal goal: String, limit: Int = 5,
                       at instant: Date? = nil) -> String? {
        let hits = retrieve(forGoal: goal, limit: limit, at: instant)
        guard !hits.isEmpty else { return nil }
        let lines = hits.map { ($0.kind == .proven ? "✓ proven: " : "⚠ obstacle: ") + $0.text }
        return "LESSONS FROM PAST RUNS (advisory — verify, don't assume):\n" + lines.joined(separator: "\n")
    }

    /// One temporal projection shared by ordinary lesson recall and the strict
    /// mission evidence graph. Legacy rows derive only from their stable event
    /// timestamp; reads never persist hydration, access, or reinforcement.
    static func temporalProjection(_ raw: Lesson, physicalOrdinal: Int,
                                   now: Date) -> TemporalLessonProjection? {
        guard physicalOrdinal >= 0, isWireDate(now),
              let lesson = lessonWithTemporalMetadata(raw),
              !hasFutureEvidence(lesson, relativeTo: now),
              let temporal = lesson.temporal else { return nil }
        let evaluation = temporal.evaluate(at: now)
        guard evaluation.isRetrievalEligible,
              evaluation.salience >= MemoryTemporalEnvelope.confidenceFloor else {
            return nil
        }
        return TemporalLessonProjection(
            lesson: lesson, physicalOrdinal: physicalOrdinal,
            salience: evaluation.salience)
    }

    private static func lessonWithTemporalMetadata(_ raw: Lesson) -> Lesson? {
        guard raw.at.isFinite else { return nil }
        let event = Date(timeIntervalSince1970: raw.at)
        guard isWireDate(event) else { return nil }
        let temporal: MemoryTemporalEnvelope
        if let stored = raw.temporal {
            guard MemoryTemporalEnvelope.storedClockAgrees(
                raw.at, with: stored.createdAt) else { return nil }
            temporal = stored
        } else {
            let rate: MemoryDecayRate = raw.kind == .obstacle ? .verySlow : .slow
            let base = raw.kind == .obstacle ? 0.9 : 0.8
            guard let derived = try? MemoryTemporalEnvelope(
                createdAt: event, decayRate: rate, baseSalience: base) else {
                return nil
            }
            temporal = derived
        }
        return Lesson(
            kind: raw.kind, text: raw.text, source: raw.source, at: raw.at,
            keywords: raw.keywords, temporal: temporal)
    }

    private static func hasFutureEvidence(_ lesson: Lesson,
                                          relativeTo now: Date) -> Bool {
        guard let temporal = lesson.temporal else { return true }
        let event = Date(timeIntervalSince1970: lesson.at)
        let futureClocks = [
            event, temporal.createdAt, temporal.updatedAt,
            temporal.accessedAt, temporal.lastConfirmedAt, temporal.retiredAt,
        ].compactMap { $0 }
        return futureClocks.contains(where: {
            $0.timeIntervalSince(now) > MemoryTemporalEnvelope.maximumFutureEvidenceSkew
        })
    }

    static func temporalLessonPrecedes(_ lhs: TemporalLessonProjection,
                                       _ rhs: TemporalLessonProjection) -> Bool {
        if lhs.lesson.at != rhs.lesson.at { return lhs.lesson.at < rhs.lesson.at }
        return lhs.physicalOrdinal < rhs.physicalOrdinal
    }

    private static func isWireDate(_ date: Date) -> Bool {
        let epoch = date.timeIntervalSince1970
        return epoch.isFinite
            && (MemoryTemporalEnvelope.minimumWireEpoch...MemoryTemporalEnvelope.maximumWireEpoch)
                .contains(epoch)
    }

    /// Bounded tail reader shared by recall and mutation. It never allocates
    /// more than the store budget, even for a sparse or hostile legacy file.
    private func boundedLessonTail() -> Data? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: path) else { return Data() }
        guard let attributes = try? manager.attributesOfItem(atPath: path),
              let sizeNumber = attributes[.size] as? NSNumber else { return nil }
        let fileSize = sizeNumber.uint64Value
        let byteLimit = UInt64(Self.maximumFileBytes)
        let start = fileSize > byteLimit ? fileSize - byteLimit : 0
        guard let handle = try? FileHandle(
            forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: start)
            var data = try handle.read(upToCount: Self.maximumFileBytes) ?? Data()
            if start > 0 {
                if let newline = data.firstIndex(of: 0x0A) {
                    data.removeSubrange(data.startIndex...newline)
                } else {
                    data.removeAll(keepingCapacity: false)
                }
            }
            return data
        } catch {
            return nil
        }
    }

    @discardableResult
    private func write(_ lessons: [Lesson]) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        guard (try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)) != nil else { return false }
        var rows: [Data] = []
        rows.reserveCapacity(min(lessons.count, capacity))
        for lesson in lessons.suffix(capacity) {
            guard let row = try? JSONEncoder().encode(lesson),
                  row.count <= Self.maximumRowBytes else { return false }
            rows.append(row)
        }
        var totalBytes = rows.reduce(0) { $0 + $1.count + 1 }
        while rows.count > 1, totalBytes > Self.maximumFileBytes {
            totalBytes -= rows.removeFirst().count + 1
        }
        guard totalBytes <= Self.maximumFileBytes else { return false }
        var body = Data(capacity: totalBytes)
        for row in rows {
            body.append(row)
            body.append(0x0A)
        }
        do {
            try body.write(to: URL(fileURLWithPath: path), options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: path)
            return true
        } catch {
            return false
        }
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
