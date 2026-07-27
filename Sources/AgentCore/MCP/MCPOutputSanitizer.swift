import Foundation

// MARK: - MCP Output Sanitizer
//
// TRUST BOUNDARY. Everything a remote MCP server returns is UNTRUSTED — produced by
// a separate process the user pointed us at — and flows straight into the model's
// context, where it can attempt prompt injection, blow up the context window, or
// carry terminal-control / zero-width bytes.
//
// This is the single chokepoint that turns raw `tools/call` content into a bounded,
// control-stripped string safe to feed the model. It does NOT attempt to neutralize
// prompt injection semantically (impossible in general — that's the loop's job:
// treat tool output as data, not instructions). It guarantees STRUCTURE: bounded
// size, no control bytes, valid UTF-8.
public enum MCPOutputSanitizer {

    /// Hard cap on text forwarded to the model from a single tool call. 64 KB is
    /// generous while preventing a hostile/buggy server from exhausting context.
    public static let maxBytes = 64 * 1024

    /// Extract + sanitize the text payload from an MCP `tools/call` result.
    /// Result shape: `{ "content": [ { "type": "text", "text": "..." } ], "isError": Bool }`.
    /// `isError` reflects the server's structured flag — we never infer success from
    /// the (untrusted, spoofable) text.
    public static func extract(from result: [String: Any]) -> (text: String, isError: Bool) {
        let isError = (result["isError"] as? Bool) ?? false

        var pieces: [String] = []
        if let content = result["content"] as? [[String: Any]] {
            for block in content {
                let type = block["type"] as? String ?? "text"
                switch type {
                case "text":
                    if let t = block["text"] as? String { pieces.append(t) }
                case "image":
                    let mime = block["mimeType"] as? String ?? "image"
                    pieces.append("[image content omitted: \(mime)]")
                case "resource":
                    if let res = block["resource"] as? [String: Any], let uri = res["uri"] as? String {
                        pieces.append("[resource: \(uri)]")
                    }
                default:
                    pieces.append("[unsupported content block: \(type)]")
                }
            }
        }

        let joined = pieces.isEmpty ? "(no content)" : pieces.joined(separator: "\n")
        return (sanitize(joined), isError)
    }

    /// Bound + strip a free-form string from an untrusted source.
    public static func sanitize(_ input: String) -> String {
        // 1. Cap by BYTES (not characters) so multibyte content can't sneak past.
        var s = input
        if s.utf8.count > maxBytes {
            let prefix = String(decoding: Array(s.utf8.prefix(maxBytes)), as: UTF8.self)
            s = prefix + "\n…[truncated: output exceeded \(maxBytes) bytes]"
        }
        // 2. Strip control AND format chars, keeping ONLY newline + tab as whitespace.
        //    This removes ANSI ESC, NUL, BEL, and crucially `\r` (carriage return can
        //    overwrite earlier rendered lines to hide content), plus the entire Unicode
        //    `.format` category — bidi overrides/isolates (U+202A–202E, U+2066–2069),
        //    ZWJ/ZWNJ, word joiner, BOM — which can visually reorder or hide injected
        //    text. An untrusted server gets no terminal-control or text-spoofing bytes.
        var out = String.UnicodeScalarView()
        out.reserveCapacity(s.unicodeScalars.count)
        for scalar in s.unicodeScalars {
            if scalar == "\n" || scalar == "\t" {
                out.append(scalar)
            } else {
                switch scalar.properties.generalCategory {
                case .control, .format:
                    break   // drop (includes \r, ESC, NUL, bidi overrides, zero-width, BOM)
                default:
                    out.append(scalar)
                }
            }
        }
        return String(out)
    }
}
