import XCTest
@testable import AgentCore

/// Council-mandated differential golden test (2026-07-03): the ActionParser was NOT extracted verbatim —
/// the old inline parser took the FIRST `{...}`; the new one ranks candidates and takes the LAST actionable
/// object (the model's true final intent). This test PINS that:
///   1. for every PREVIOUSLY-VALID single-object output (the overwhelming common case), OLD and NEW dispatch
///      IDENTICALLY — the extraction change is invisible where it matters;
///   2. the multi-object behavior change (first → last-intent) is INTENTIONAL and pinned.
/// `LegacyActionParser` below is a faithful copy of the old inline parser (from HeadlessAgentLoop.swift@HEAD)
/// so the differential is real, not a re-description.
final class ActionParserGoldenTests: XCTestCase {

    // MARK: faithful copy of the OLD inline parser (first-object based)
    private enum LegacyActionParser {
        static func parse(_ raw: String) -> (tool: String?, done: Bool)? {
            guard let json = extractJSONObject(raw),
                  let data = json.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            let node = (obj["next_action"] as? [String: Any]) ?? (obj["action"] as? [String: Any]) ?? obj
            let done = (obj["done"] as? Bool) ?? (node["done"] as? Bool)
                ?? ((node["type"] as? String)?.lowercased() == "done")
            let tool = (node["tool"] as? String) ?? (node["name"] as? String)
            guard done == true || (tool != nil && !(tool!.isEmpty)) else { return nil }
            return (tool, done == true)
        }
        static func extractJSONObject(_ s: String) -> String? {
            var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let fence = t.range(of: "```") {
                t = String(t[fence.upperBound...])
                if t.lowercased().hasPrefix("json") { t = String(t.dropFirst(4)) }
                if let close = t.range(of: "```") { t = String(t[..<close.lowerBound]) }
                t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let start = t.firstIndex(of: "{") else { return nil }
            var depth = 0, inString = false, escaped = false
            var idx = start
            while idx < t.endIndex {
                let c = t[idx]
                if inString {
                    if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                } else {
                    if c == "\"" { inString = true } else if c == "{" { depth += 1 }
                    else if c == "}" { depth -= 1; if depth == 0 { return String(t[start...idx]) } }
                }
                idx = t.index(after: idx)
            }
            return nil
        }
    }

    /// Previously-valid SINGLE-object outputs — old and new MUST dispatch identically.
    private let singleObjectCorpus: [String] = [
        #"{"tool":"read_file","parameters":{"path":"a.swift"}}"#,
        #"{"name":"read_file","parameters":{}}"#,                                   // tool via "name"
        "```json\n{\"tool\":\"write_file\",\"parameters\":{}}\n```",               // fenced
        "Sure — here you go:\n{\"tool\":\"run_command\",\"parameters\":{\"command\":\"ls\"}}", // prose before
        #"{"action":{"tool":"search_code","input":{"q":"x"}}}"#,                    // action wrapper
        #"{"next_action":{"name":"edit_file","parameters":{}}}"#,                   // next_action wrapper
        #"{"done":true,"summary":"all set"}"#,                                      // done
        #"{"action":{"type":"done"}}"#,                                            // type: done
        "I think we should refactor this later.",                                  // prose-only → both nil
        "no json here at all",                                                     // no json → both nil
    ]

    func testSingleObjectDispatchIsIdenticalOldVsNew() {
        for raw in singleObjectCorpus {
            let old = LegacyActionParser.parse(raw)
            let new = ActionParser.parse(raw)
            XCTAssertEqual(old?.tool, new?.tool, "tool dispatch diverged for: \(raw)")
            XCTAssertEqual(old?.done, new?.done, "done flag diverged for: \(raw)")
            XCTAssertEqual(old == nil, new == nil, "parse-vs-nil diverged for: \(raw)")
        }
    }

    /// The INTENTIONAL change: two actionable objects in one output. Old took the FIRST; new takes the LAST
    /// (the model's true final intent). Pin the new behavior so it can't silently regress.
    func testMultiObjectTakesLastIntentNotFirst() {
        let raw = #"{"tool":"read_file","parameters":{}} then actually {"tool":"write_file","parameters":{}}"#
        XCTAssertEqual(LegacyActionParser.parse(raw)?.tool, "read_file", "old parser took the FIRST object")
        XCTAssertEqual(ActionParser.parse(raw)?.tool, "write_file", "new parser takes the LAST actionable intent")
    }
}
