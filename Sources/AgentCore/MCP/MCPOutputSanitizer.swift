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
    /// Aggregate decoded-image ceiling for one MCP tool result. The encoded-length preflight below
    /// rejects oversized base64 before allocating its decoded representation.
    public static let maxImageBytes = 8 * 1024 * 1024
    /// A server cannot turn one tool result into an unbounded image batch even when every image is tiny.
    public static let maxImages = 4

    public struct ExtractedContent: Sendable, Equatable {
        public let text: String
        public let isError: Bool
        public let attachments: [MediaAttachment]

        public init(text: String, isError: Bool, attachments: [MediaAttachment]) {
            self.text = text
            self.isError = isError
            self.attachments = attachments
        }
    }

    /// Extract + sanitize the text payload from an MCP `tools/call` result.
    /// Result shape: `{ "content": [ { "type": "text", "text": "..." } ], "isError": Bool }`.
    /// `isError` reflects the server's structured flag — we never infer success from
    /// the (untrusted, spoofable) text.
    public static func extract(from result: [String: Any]) -> (text: String, isError: Bool) {
        let extracted = extractContent(from: result)
        return (extracted.text, extracted.isError)
    }

    /// Extract text plus strictly validated raster image blocks. Base64 never enters the returned text;
    /// callers receive decoded bytes as `MediaAttachment`s for the provider's existing vision encoder.
    /// SVG is deliberately unsupported because active content does not belong in an image trust boundary.
    public static func extractContent(from result: [String: Any]) -> ExtractedContent {
        let isError = (result["isError"] as? Bool) ?? false

        var pieces: [String] = []
        var attachments: [MediaAttachment] = []
        var imageBytes = 0
        var imageBlocks = 0
        if let content = result["content"] as? [[String: Any]] {
            for block in content {
                let type = block["type"] as? String ?? "text"
                switch type {
                case "text":
                    if let t = block["text"] as? String { pieces.append(t) }
                case "image":
                    imageBlocks += 1
                    guard imageBlocks <= maxImages else {
                        if imageBlocks == maxImages + 1 {
                            pieces.append("[image content rejected: image-count limit exceeded]")
                        }
                        continue
                    }
                    let remaining = max(0, maxImageBytes - imageBytes)
                    switch validatedImageAttachment(block, maxDecodedBytes: remaining) {
                    case .success(let attachment):
                        let bytes = attachment.inlineByteCount
                        attachments.append(attachment)
                        imageBytes += bytes
                        pieces.append("[image attached: \(attachment.mimeType), \(bytes) bytes]")
                    case .failure(let reason):
                        pieces.append("[image content rejected: \(reason)]")
                    }
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
        return ExtractedContent(text: sanitize(joined), isError: isError, attachments: attachments)
    }

    private enum ImageValidation {
        case success(MediaAttachment)
        case failure(String)
    }

    private static let supportedImageMIMEs: Set<String> = [
        "image/jpeg", "image/png", "image/gif", "image/webp",
    ]

    private static func validatedImageAttachment(
        _ block: [String: Any], maxDecodedBytes: Int
    ) -> ImageValidation {
        guard maxDecodedBytes > 0 else { return .failure("decoded-byte limit exceeded") }
        guard let rawMIME = block["mimeType"] as? String else { return .failure("missing MIME type") }
        let mime = rawMIME.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard supportedImageMIMEs.contains(mime) else { return .failure("unsupported MIME type") }
        guard let encoded = block["data"] as? String, !encoded.isEmpty else {
            return .failure("missing base64 data")
        }

        // Four base64 characters encode at most three bytes. Bound the encoded string before decoding,
        // with four bytes of padding slack for the final quartet.
        let encodedLimit = ((maxDecodedBytes + 2) / 3) * 4 + 4
        guard encoded.utf8.count <= encodedLimit else { return .failure("decoded-byte limit exceeded") }
        guard let data = Data(base64Encoded: encoded), !data.isEmpty else {
            return .failure("invalid base64 data")
        }
        guard data.count <= maxDecodedBytes else { return .failure("decoded-byte limit exceeded") }
        guard hasExpectedMagic(data, mime: mime) else {
            return .failure("payload does not match MIME type")
        }
        return .success(MediaAttachment(kind: .image, mimeType: mime, payload: .inline(data)))
    }

    private static func hasExpectedMagic(_ data: Data, mime: String) -> Bool {
        switch mime {
        case "image/jpeg":
            return data.starts(with: [0xFF, 0xD8, 0xFF])
        case "image/png":
            return data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        case "image/gif":
            return data.starts(with: Array("GIF87a".utf8)) || data.starts(with: Array("GIF89a".utf8))
        case "image/webp":
            guard data.count >= 12 else { return false }
            return data.starts(with: Array("RIFF".utf8))
                && data.dropFirst(8).starts(with: Array("WEBP".utf8))
        default:
            return false
        }
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
