import Foundation

/// A structured understanding of a video/audio file — the navigable index behind "what's this about",
/// "give me the transcript", "what scenes do I need to watch", and "at what time does X happen". We
/// ask a vision model (Gemini) for this shape so the answer is searchable + jumpable, not a wall of
/// prose. Cached per file so follow-up questions hit the index, not the API.
public struct MediaIndex: Sendable, Codable, Equatable {
    public struct Moment: Sendable, Codable, Equatable {
        public let at: String          // MM:SS or HH:MM:SS
        public let label: String
        public let detail: String?     // why it matters / what's in it
        public let speaker: String?    // for transcript segments, when known
        public init(at: String, label: String, detail: String? = nil, speaker: String? = nil) {
            self.at = at; self.label = label; self.detail = detail; self.speaker = speaker
        }
    }

    public let summary: String
    public let timeline: [Moment]      // scenes / chapters
    public let transcript: [Moment]    // timestamped spoken text
    public let keyMoments: [Moment]    // the "you need to watch this" highlights
    public let durationHint: String?

    public init(summary: String, timeline: [Moment] = [], transcript: [Moment] = [],
                keyMoments: [Moment] = [], durationHint: String? = nil) {
        self.summary = summary; self.timeline = timeline; self.transcript = transcript
        self.keyMoments = keyMoments; self.durationHint = durationHint
    }

    /// The strict-JSON contract we ask the model to emit. Kept here so the prompt and the parser
    /// can't drift apart.
    public static let jsonSchemaHint = """
    {
      "summary": "1-3 sentence overview of the whole clip",
      "durationHint": "approx length like 4:35 if knowable, else null",
      "timeline":   [{"at":"MM:SS","label":"scene/chapter title","detail":"what happens"}],
      "transcript": [{"at":"MM:SS","speaker":"name or null","label":"spoken text verbatim"}],
      "keyMoments": [{"at":"MM:SS","label":"why you should watch this moment","detail":null}]
    }
    """

    /// Parse a model reply into a `MediaIndex`. Tolerant: pulls the first balanced JSON object out of
    /// surrounding prose/markdown fences, and treats every section but `summary` as optional.
    public static func parse(_ raw: String) -> MediaIndex? {
        guard let json = firstJSONObject(in: raw),
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        guard let summary = (obj["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else { return nil }

        func moments(_ key: String) -> [Moment] {
            (obj[key] as? [[String: Any]] ?? []).compactMap { m in
                guard let at = m["at"] as? String, let label = m["label"] as? String else { return nil }
                return Moment(at: at, label: label,
                              detail: (m["detail"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                              speaker: (m["speaker"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            }
        }
        return MediaIndex(summary: summary,
                          timeline: moments("timeline"),
                          transcript: moments("transcript"),
                          keyMoments: moments("keyMoments"),
                          durationHint: (obj["durationHint"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Find moments whose label/detail/speaker match a free-text query — the "when does X happen" search.
    public func search(_ query: String) -> [Moment] {
        let q = query.lowercased()
        let terms = q.split(whereSeparator: { $0 == " " }).map(String.init).filter { $0.count > 2 }
        guard !terms.isEmpty else { return [] }
        func score(_ m: Moment) -> Int {
            let hay = (m.label + " " + (m.detail ?? "") + " " + (m.speaker ?? "")).lowercased()
            return terms.reduce(0) { $0 + (hay.contains($1) ? 1 : 0) }
        }
        return (timeline + keyMoments + transcript)
            .map { ($0, score($0)) }.filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    /// Extract the first balanced `{...}` object, ignoring braces inside strings. Returns nil if none.
    static func firstJSONObject(in text: String) -> String? {
        let chars = Array(text)
        guard let start = chars.firstIndex(of: "{") else { return nil }
        var depth = 0, inString = false, escaped = false
        for i in start..<chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else {
                if c == "\"" { inString = true }
                else if c == "{" { depth += 1 }
                else if c == "}" { depth -= 1; if depth == 0 { return String(chars[start...i]) } }
            }
        }
        return nil
    }
}
