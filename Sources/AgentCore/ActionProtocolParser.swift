import Foundation

/// Tolerant parser for the loop's JSON action object — the single most load-bearing function in the
/// provider-agnostic TEXT protocol. It turns a model's free-form completion into a dispatchable action.
/// The contract is "reply with ONLY one JSON object — no prose, no code fences, before or after", but
/// models routinely violate it, so the parser is forgiving in a *directed* way: it prefers the object
/// that is actually the model's action over stray `{...}` in prose or illustrative examples.
///
/// Disambiguation rules (Captain substrate — the loop Captain runs its own self-improvement on, so a
/// bug here corrupts every provider at once). Perfect disambiguation is impossible on a text protocol —
/// that residual ambiguity is exactly what native tool-calling eliminates — so these rules pick the
/// safest defensible interpretation and FAIL CLOSED (nudge) rather than guess when intent is unclear:
///   • A BARE object (not inside a ``` fence) beats a FENCED one: the contract forbids fencing the real
///     action, so a fenced object is treated as an illustrative example. Only if there is no bare
///     actionable object do fenced ones count (models often wrap their sole action in a fence anyway).
///   • Within a tier, the LAST object with actionable intent wins: the contract forbids prose AFTER the
///     action, so a trailing action-shaped brace is doubly non-compliant, and "don't run {X}, instead
///     {Y}" resolves to Y.
///   • "Malformed action" (has a tool/done but invalid params) is distinct from "not an action" (no
///     actionable signal). A malformed LAST action fails closed — it does NOT fall back to an earlier
///     valid example — because the model's final intent was that (broken) action, so nudging beats
///     dispatching a stale example.
///   • Brace scanning ignores string/escape state at depth 0, so an unbalanced quote in prose can't
///     swallow the real opening brace. Inside an object, string/escape state IS tracked so braces in
///     JSON string values (`echo {hi}`) never split an object early.
///   • Stringified params (`"parameters":"{...}"`) are parsed; `done` is read from a real Bool, a
///     stringified bool, or `type:"done"`.
///
/// Pinned by an adversarial fuzz corpus in `ActionParserTests`. This file stays small and single-purpose.
enum ActionParser {
    struct Action {
        var thinking: String?
        var tool: String?
        var parameters: [String: Any]
        var done: Bool
        var summary: String?
        var message: String?
    }

    private enum DecodeResult {
        case action(Action)   // a valid, dispatchable action
        case malformed        // had actionable intent (tool/done) but was invalid (e.g. bad params)
        case notAnAction      // no actionable signal — a stray prose/example object; skip it
    }

    /// Parse the model's completion into an action. Prefers bare (unfenced) objects over fenced ones,
    /// and within a tier takes the last object with actionable intent — failing closed (nil) if that
    /// last intent was malformed, or if no actionable object exists.
    static func parse(_ raw: String) -> Action? {
        let scan = scanCandidates(raw)
        // A TRUNCATED final action (model hit its token limit mid-object) leaves an unterminated,
        // intent-bearing tail. That is the model's last intent, so fail closed rather than dispatch a
        // stale earlier candidate.
        if scan.trailingIntent { return nil }
        for preferBare in [true, false] {
            var last: DecodeResult = .notAnAction
            for candidate in scan.candidates where candidate.fenced == !preferBare {
                let result = decode(candidate.json)
                if case .notAnAction = result { continue }   // skip pure prose/example objects
                last = result                                // remember the last object with intent
            }
            switch last {
            case .action(let action): return action
            case .malformed: return nil                      // fail closed; don't fall back to a fenced example
            case .notAnAction: continue                      // no actionable object in this tier — try next
            }
        }
        return nil
    }

    /// Keys that mark an object as an ATTEMPTED action (vs. a stray prose/example object). `type` is
    /// deliberately excluded: a `{"type":"message"}` control object is prose, not an action attempt.
    private static let intentKeys = ["tool", "name", "done", "next_action", "action"]

    private static func decode(_ json: String) -> DecodeResult {
        let strict = jsonObject(from: json)
        // Local models (esp. Python/JS-backed servers) emit relaxed literals — single-quoted strings,
        // unquoted keys, `True`/`False`/`None`, trailing commas. When strict JSON fails but the text is
        // clearly an action attempt, try a conservative relaxation and re-parse so those models are
        // first-class on the text protocol instead of nudged forever. Relaxation is a pure fallback: it
        // only runs on intent-bearing candidates and only counts if the normalized form re-parses.
        let obj: [String: Any]
        if let strict { obj = strict }
        else if hasActionIntentRaw(json), let relaxed = relaxedJSONObject(from: json) { obj = relaxed }
        else {
            // Un-parseable and un-relaxable: if it still LOOKS like an action attempt, fail closed so a
            // later malformed action can't fall back to an earlier example; else it's prose.
            return hasActionIntentRaw(json) ? .malformed : .notAnAction
        }

        // Tolerate a nested "next_action"/"action" wrapper (the GUI monolith's shape) too.
        let node = (obj["next_action"] as? [String: Any]) ?? (obj["action"] as? [String: Any]) ?? obj

        let tool = (node["tool"] as? String) ?? (node["name"] as? String)
        let hasTool = tool != nil && !(tool!.isEmpty)
        let done = parseDone(obj: obj, node: node, hasTool: hasTool)

        guard done || hasTool else {
            // Not dispatchable. If the object carried action-shaped keys (e.g. `{"done":false}` or a
            // non-string `{"tool":123}`), it's a MALFORMED attempt → fail closed; otherwise it's prose.
            let hadIntent = hasActionIntent(obj) || hasActionIntent(node)
            return hadIntent ? .malformed : .notAnAction
        }

        // Contradictory intent: an explicit `done:true` alongside a real tool means "stop" and "do one
        // more thing" at once. Fail closed (nudge) rather than silently completing and skipping the tool.
        if done && hasTool { return .malformed }

        // Fail-closed for a TOOL dispatch: a present-but-malformed params field must NOT silently become
        // empty args on a stateful tool. A done-only action tolerates junk params it won't use.
        let params: [String: Any]
        if hasTool {
            guard let resolved = resolveParameters(node) else { return .malformed }
            params = resolved
        } else {
            params = resolveParameters(node) ?? [:]
        }

        // Summary may live top-level, in the wrapper node, or inside the (possibly stringified) params.
        let summary = (obj["summary"] as? String) ?? (node["summary"] as? String) ?? (params["summary"] as? String)
        return .action(Action(
            thinking: obj["thinking"] as? String ?? node["thinking"] as? String,
            tool: tool,
            parameters: params,
            done: done,
            summary: summary,
            message: obj["message"] as? String
        ))
    }

    private static func hasActionIntent(_ dict: [String: Any]) -> Bool {
        for key in intentKeys where dict[key] != nil { return true }
        return false
    }

    /// Detect action intent in RAW (possibly invalid) text. Matches an intent key that is quoted
    /// (`"tool"`), single-quoted (`'tool'`), or a bare word (`tool:`) following a delimiter — so a
    /// JS/Python-style object literal from a local model (`{tool:"x"}`) is still recognized as an
    /// attempted action and fails closed rather than being mistaken for prose. (Note: we DETECT such
    /// literals to fail closed; actually PARSING relaxed JSON for local models is a separate follow-up.)
    private static func hasActionIntentRaw(_ json: String) -> Bool {
        let keys = intentKeys.joined(separator: "|")
        let patterns = [
            "(?:^|[{,\\s])[\"']?(" + keys + ")[\"']?\\s*:",  // any intent key
            "[\"']?type[\"']?\\s*:\\s*[\"']?done",            // the `type:"done"` marker specifically —
                                                              // `type` is otherwise excluded, but a
                                                              // truncated/malformed done must fail closed
        ]
        for pattern in patterns {
            if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               re.firstMatch(in: json, range: NSRange(json.startIndex..., in: json)) != nil {
                return true
            }
        }
        for key in intentKeys where json.contains("\"\(key)\"") { return true }  // regex-fail fallback
        return false
    }

    /// Resolve the parameter dict. Returns `[:]` when no params key is present (valid — e.g. list_files)
    /// or when it is an empty/whitespace string (treated as absent; per-tool required-arg enforcement is
    /// the tool layer's job, which fail-closes for a missing path etc.), the dict when present (including
    /// a stringified JSON object), and `nil` to signal a present-but-MALFORMED params field.
    private static func resolveParameters(_ node: [String: Any]) -> [String: Any]? {
        for key in ["parameters", "input"] {
            guard let raw = node[key] else { continue }
            if let dict = raw as? [String: Any] { return dict }
            if let s = raw as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return [:] }                     // empty/whitespace string ⇒ no params
                if let dict = jsonObject(from: trimmed) { return dict } // stringified params
            }
            return nil   // present but neither a dict nor a parseable object-string ⇒ malformed
        }
        return [:]       // no params key at all ⇒ empty
    }

    /// Accept `done` as a real Bool, a stringified bool (`"true"`/`"yes"`/`"false"`/`"no"`), or a
    /// `type: "done"` marker. An explicit stringified `false` wins over a later `type` check so a model
    /// that says `{"done":"false","type":"done"}` is not falsely completed. All string forms are
    /// trimmed of whitespace AND newlines. `type` is treated ONLY as a done marker — never as a tool
    /// name — so a `{"type":"message",...}` control object is not mis-dispatched as a nonexistent tool.
    private static func parseDone(obj: [String: Any], node: [String: Any], hasTool: Bool) -> Bool {
        if let b = obj["done"] as? Bool { return b }
        if let b = node["done"] as? Bool { return b }
        if let raw = (obj["done"] as? String) ?? (node["done"] as? String) {
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes": return true
            case "false", "no": return false
            default: break
            }
        }
        // `type:"done"` is the WEAK done marker: honor it only when there is no tool, so a real tool
        // action that happens to carry `type:"done"` dispatches the tool rather than completing early.
        if !hasTool, (node["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "done" {
            return true
        }
        return false
    }

    /// Balance-aware extraction of the FIRST top-level JSON object in `s`. Kept for callers that just
    /// want "the JSON blob in this text" — `AgentHooks`, `PlanParser`, `PlanExecuteLoop`. For action
    /// dispatch use `parse`, which ranks across all candidates.
    static func extractJSONObject(_ s: String) -> String? {
        candidateJSONObjects(s).first?.json
    }

    /// Return every top-level balanced `{...}` substring, in order, each tagged with whether it sits
    /// inside a markdown code fence. At depth 0 (scanning prose) only an opening `{` and fence markers
    /// matter — quotes are ignored, so an unbalanced quote in prose cannot suppress the real object.
    /// Inside an object, string/escape state is tracked so braces within JSON string values never split
    /// or end an object early.
    ///
    /// Fence detection follows CommonMark closely enough to be robust without a full markdown parser:
    /// a fence is a run of ≥3 `` ` `` or `~` at the START of a line (after optional whitespace); the
    /// closing fence must use the SAME character and be at least as long as the opener (so a 4-backtick
    /// fence containing an inner 3-backtick block isn't closed early). Exotic nested cases beyond this
    /// remain inherently ambiguous on a text protocol — the residual native tool-calling removes.
    static func candidateJSONObjects(_ s: String) -> [(json: String, fenced: Bool)] {
        scanCandidates(s).candidates
    }

    /// Full scan result: the balanced candidates plus whether the text ends with an UNTERMINATED,
    /// intent-bearing object (a truncated final action — model cut off mid-emit).
    private struct ScanResult {
        let candidates: [(json: String, fenced: Bool)]
        let trailingIntent: Bool
    }

    private static func scanCandidates(_ s: String) -> ScanResult {
        var results: [(json: String, fenced: Bool)] = []
        var depth = 0, inString = false, escaped = false
        var fenceChar: Character? = nil     // non-nil ⇒ currently inside a fence, holding its char
        var fenceLen = 0                     // opener run length (close must be ≥ this)
        var atLineStart = true               // true at start-of-line, preserved through leading whitespace
        var start: String.Index? = nil
        var startFenced = false
        var idx = s.startIndex
        while idx < s.endIndex {
            let c = s[idx]
            if depth > 0 {
                if inString {
                    if escaped { escaped = false }
                    else if c == "\\" { escaped = true }
                    else if c == "\"" { inString = false }
                } else if c == "\"" {
                    inString = true
                } else if c == "{" {
                    depth += 1
                } else if c == "}" {
                    depth -= 1
                    if depth == 0, let s0 = start {
                        results.append((String(s[s0...idx]), startFenced))
                        start = nil
                    }
                }
                idx = s.index(after: idx)
                continue
            }
            // depth == 0 — scanning prose between objects.
            if c == "\n" {
                atLineStart = true
                idx = s.index(after: idx)
            } else if c == " " || c == "\t" {
                idx = s.index(after: idx)            // whitespace preserves line-start status
            } else if c == "`" || c == "~" {
                var run = 0
                var j = idx
                while j < s.endIndex && s[j] == c { run += 1; j = s.index(after: j) }
                if run >= 3 && atLineStart {
                    if fenceChar == nil { fenceChar = c; fenceLen = run }              // open
                    else if fenceChar == c && run >= fenceLen { fenceChar = nil; fenceLen = 0 } // matched close
                }
                atLineStart = false
                idx = j
            } else if c == "{" {
                start = idx; startFenced = (fenceChar != nil); depth = 1; atLineStart = false
                idx = s.index(after: idx)
            } else {
                atLineStart = false
                idx = s.index(after: idx)
            }
        }
        // If we ended still inside an object, the tail is a truncated final emission. Flag it as intent
        // only if it actually looks like an action attempt (so trailing prose with a stray `{` is inert).
        let trailingIntent = start.map { hasActionIntentRaw(String(s[$0...])) } ?? false
        return ScanResult(candidates: results, trailingIntent: trailingIntent)
    }

    private static func jsonObject(from json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return obj
    }

    /// Conservatively normalize a relaxed (JSON5/JS/Python-ish) object literal to strict JSON and parse
    /// it. Handles the deviations local models actually emit: single-quoted strings, unquoted object
    /// keys, `True`/`False`/`None`, and a SINGLE trailing comma before a close — WITHOUT touching the
    /// contents of valid strings (the walk is string-state aware). Returns nil if the normalized form
    /// still isn't a JSON object, so it can only turn a previously-unparseable action into a parsed one,
    /// never corrupt a valid parse. Deliberately does NOT "repair" genuinely broken structure: a mid-run
    /// `,,` (empty member) is left invalid so it fails closed rather than silently dropping an element.
    ///
    /// Known limitation (documented, fail-closed): a single-quoted string that itself contains an
    /// unescaped `}` truncates early in the candidate scanner (which balances `{}` and tracks only `"`
    /// strings), so it won't parse. Use double quotes for such values. A compatibility gap, never corruption.
    private static func relaxedJSONObject(from json: String) -> [String: Any]? {
        jsonObject(from: normalizeRelaxedJSON(json))
    }

    private static func isBarewordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "." || c == "+" || c == "-"
    }

    static func normalizeRelaxedJSON(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 16)
        var stack: [Character] = []          // enclosing container: '{' or '['
        var expectKey = false                // at a spot where an object key may begin (survives whitespace)

        // Strip a SINGLE legitimate trailing comma (plus whitespace) just before a close token — but ONLY
        // when it follows a real value/close. A comma preceded by `{`/`[`/`,`/`:` marks an empty member
        // (`[1,,]`, `[,]`, `{,}`), which is a genuine error — leave it so the parse fails closed.
        func stripTrailingComma() {
            while let last = out.last, last == " " || last == "\t" || last == "\n" || last == "\r" {
                out.removeLast()
            }
            guard out.last == ",", out.count > 1 else { return }
            var k = out.index(out.endIndex, offsetBy: -2)          // the char before the comma
            while k > out.startIndex, out[k] == " " || out[k] == "\t" || out[k] == "\n" || out[k] == "\r" {
                k = out.index(before: k)
            }
            let prev = out[k]
            if prev == "{" || prev == "[" || prev == "," || prev == ":" { return }  // empty member — keep it invalid
            out.removeLast()                                        // safe trailing comma after a value/close
        }

        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            switch c {
            case "\"":
                // A strict double-quoted string: copy verbatim (escape-aware).
                var j = s.index(after: i)
                out.append("\"")
                var escaped = false
                while j < s.endIndex {
                    let d = s[j]
                    out.append(d)
                    if escaped { escaped = false }
                    else if d == "\\" { escaped = true }
                    else if d == "\"" { j = s.index(after: j); break }
                    j = s.index(after: j)
                }
                expectKey = false; i = j
            case "'":
                // A single-quoted string → convert to a double-quoted one, escaping inner double quotes.
                var j = s.index(after: i)
                out.append("\"")
                while j < s.endIndex {
                    let d = s[j]
                    if d == "\\" {
                        let k = s.index(after: j)
                        if k < s.endIndex {
                            let e = s[k]
                            if e == "'" { out.append("'") }            // \' → '
                            else { out.append("\\"); out.append(e) }   // keep other escapes intact
                            j = s.index(after: k); continue
                        }
                        out.append("\\"); j = s.index(after: j); continue
                    }
                    if d == "'" { j = s.index(after: j); break }        // end of single-quoted string
                    if d == "\"" { out.append("\\\"") } else { out.append(d) }
                    j = s.index(after: j)
                }
                out.append("\"")
                expectKey = false; i = j
            case "{":
                stack.append("{"); out.append("{"); expectKey = true; i = s.index(after: i)
            case "[":
                stack.append("["); out.append("["); expectKey = false; i = s.index(after: i)
            case "}", "]":
                stripTrailingComma()
                if !stack.isEmpty { stack.removeLast() }
                out.append(c); expectKey = false; i = s.index(after: i)
            case ",":
                out.append(","); expectKey = (stack.last == "{"); i = s.index(after: i)
            case ":":
                out.append(":"); expectKey = false; i = s.index(after: i)
            case " ", "\t", "\n", "\r":
                out.append(c); i = s.index(after: i)                   // whitespace preserves expectKey
            default:
                // A bareword: an unquoted key, a Python literal, a number, or a JSON keyword.
                var j = i
                var word = ""
                while j < s.endIndex, isBarewordChar(s[j]) { word.append(s[j]); j = s.index(after: j) }
                if word.isEmpty {
                    out.append(c); i = s.index(after: i)               // stray punctuation — copy through
                } else {
                    switch word {
                    case "True": out.append("true")
                    case "False": out.append("false")
                    case "None": out.append("null")
                    default:
                        if expectKey && stack.last == "{" {
                            out.append("\"" + word + "\"")             // unquoted object key → quote it
                        } else {
                            out.append(word)                           // number / true / false / null
                        }
                    }
                    expectKey = false; i = j
                }
            }
        }
        return out
    }
}
