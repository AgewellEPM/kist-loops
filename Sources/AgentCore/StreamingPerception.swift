import Foundation

/// Continuous, always-on perception: instead of the agent taking a discrete screenshot every turn, this
/// watches the screen as a stream — each `tick()` captures a frame, describes it with a fast vision model
/// (Moondream caption/query, cloud or local), and maintains a live "what's on screen right now" state plus
/// an event log. It answers two questions cheaply, without a fresh big-model round-trip:
///   • "what's on screen?"  → `latestObservation()`
///   • "did something happen?" → `drainEvents()` (screen CHANGED, or a watched thing APPEARED)
///
/// This is the "fast eyes, slow brain" split: perception runs continuously and cheaply; the decision model
/// samples it or is WOKEN by an event, instead of re-perceiving from scratch each step.
///
/// An actor for safe concurrent access from a background capture loop AND the agent's tool calls. It is
/// TICK-DRIVEN (the timer lives in the production shell) so the whole engine — change detection, watch
/// matching, state — is deterministically unit-tested with scripted frames. Capture/perceive are injected,
/// so tests never need a real screen or model.
public actor StreamingPerception {

    public struct Observation: Sendable, Equatable {
        public let frame: Int
        public let text: String
    }

    public struct Event: Sendable, Equatable {
        public enum Kind: String, Sendable { case changed, appeared }
        public let frame: Int
        public let kind: Kind
        public let detail: String
    }

    public typealias Capture = @Sendable () async -> (data: Data, width: Int, height: Int)?
    public typealias Perceive = @Sendable (_ frameData: Data) async throws -> String

    private let capture: Capture
    private let perceive: Perceive
    private let changeThreshold: Double
    private var watches: [String]
    private var frame = 0
    private var latest: Observation?
    private var events: [Event] = []
    /// Hash of the last captured FRAME BYTES — identical pixels skip the (costly, non-deterministic)
    /// perceive call rather than re-describing a static screen and churning spurious change events.
    private var lastFrameHash: Int?
    /// Bound the in-memory event log so a long-running watch can't grow unbounded.
    private let maxEvents = 500

    public init(capture: @escaping Capture,
                perceive: @escaping Perceive,
                watches: [String] = [],
                changeThreshold: Double = 0.7) {
        self.capture = capture
        self.perceive = perceive
        // Sanitize watches up-front (init has no addWatch guard): an empty/whitespace keyword would
        // `contains`-match EVERY frame and fire a false `appeared` forever.
        self.watches = Self.sanitizeWatches(watches)
        self.changeThreshold = changeThreshold
    }

    /// One perception step. Captures a frame and describes it; on failure it KEEPS the last good state
    /// (a dropped frame must not erase what we last knew or emit a false event). An IDENTICAL frame skips
    /// perceive (cost + stability). Returns the new observation, or the previous one on skip/failure.
    ///
    /// NOTE: `drainEvents()` assumes a SINGLE logical consumer per session — a second interleaved drainer
    /// would steal the wake signal. `WaitForScreenTool` owns a private session, so that holds today; the
    /// future always-on shared session must give each consumer its own cursor (fan-out), not this drain.
    @discardableResult
    public func tick() async -> Observation? {
        guard let shot = await capture() else { return latest }
        let hash = shot.data.hashValue
        if let lastFrameHash, lastFrameHash == hash { return latest }   // identical pixels → skip perceive
        let text: String
        do { text = try await perceive(shot.data) } catch { return latest }
        lastFrameHash = hash
        frame += 1
        let obs = Observation(frame: frame, text: text)

        if let prev = latest {
            if Self.changed(prev.text, text, threshold: changeThreshold) {
                record(Event(frame: frame, kind: .changed, detail: "screen changed"))
            }
        } else {
            // unknown → first concrete state IS a change; let a change-watcher react to the first paint.
            record(Event(frame: frame, kind: .changed, detail: "initial state"))
        }
        for w in watches where Self.watchMatches(text, w) {
            record(Event(frame: frame, kind: .appeared, detail: w))
        }
        latest = obs
        return obs
    }

    public func latestObservation() -> Observation? { latest }

    /// Return and CLEAR the accumulated events (so each caller sees each event once — the wake signal).
    /// Single-consumer per session (see `tick()` note).
    public func drainEvents() -> [Event] {
        defer { events.removeAll() }
        return events
    }

    public func addWatch(_ keyword: String) {
        let k = Self.normalizeKeyword(keyword)
        guard !k.isEmpty, !watches.contains(k) else { return }
        watches.append(k)
    }

    public func frameCount() -> Int { frame }

    private func record(_ e: Event) {
        events.append(e)
        if events.count > maxEvents { events.removeFirst(events.count - maxEvents) }
    }

    // MARK: - Pure change heuristic (testable without the actor)

    /// True when two frame descriptions differ enough to count as a real change. Uses token-set Jaccard
    /// similarity so trivial VLM caption wording jitter ("a menu" vs "the menu") isn't a false change,
    /// but a genuine scene change (menu → game world) is.
    public static func changed(_ a: String, _ b: String, threshold: Double = 0.7) -> Bool {
        let ta = tokens(a), tb = tokens(b)
        if ta.isEmpty && tb.isEmpty { return false }
        let union = ta.union(tb).count
        guard union > 0 else { return false }
        let similarity = Double(ta.intersection(tb).count) / Double(union)
        return similarity < threshold
    }

    static func tokens(_ s: String) -> Set<String> {
        // Keep multi-char words AND any all-digit token (even single digit) so a HUD delta like "5"→"6"
        // or "100"→"101" registers as a change; drop lone letters (article/punctuation noise).
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count > 1 || $0.allSatisfy(\.isNumber) })
    }

    /// Whole-WORD watch match: `"yes"` matches `"Yes."` but NOT `"yesterday"`/`"eyes"`. Word boundaries
    /// (regex `\b`), case-insensitive; internal whitespace in a multi-word keyword is normalized to one
    /// space. Falls back to a bounded substring only if the regex fails to compile.
    static func watchMatches(_ text: String, _ keyword: String) -> Bool {
        let kw = normalizeKeyword(keyword)
        guard !kw.isEmpty else { return false }
        // Match each word bounded, separated by ANY whitespace run, so "main menu" matches "main   menu".
        let words = kw.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
        let pattern = "\\b" + words.joined(separator: "\\s+") + "\\b"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text.lowercased().contains(kw.lowercased())
        }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Trim, lowercase-agnostic, collapse internal whitespace runs to a single space.
    static func normalizeKeyword(_ keyword: String) -> String {
        keyword.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func sanitizeWatches(_ watches: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for w in watches {
            let k = normalizeKeyword(w)
            guard !k.isEmpty, !seen.contains(k) else { continue }
            seen.insert(k); out.append(k)
        }
        return out
    }
}
