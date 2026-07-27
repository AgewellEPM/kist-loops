import Foundation

/// A piece of non-text media attached to a chat turn — an image, video, audio clip, or PDF the
/// user dragged into the terminal (or referenced with `@path`). The agent loop carries these
/// alongside the prompt text; vision-capable providers (Gemini today) encode them into the request
/// so the model can actually SEE/HEAR what the user is talking about.
///
/// `payload` is either bytes sent inline (base64 in the request — fine for small/short media) or a
/// provider-side file reference (e.g. a Gemini Files API `fileUri` for big or reusable media). The
/// resolver decides which based on size/duration; providers honor whichever they're handed.
public struct MediaAttachment: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable, CaseIterable { case image, video, audio, pdf }

    public enum Payload: Sendable, Codable, Equatable {
        case inline(Data)        // raw bytes, base64-encoded into the request part
        case fileURI(String)     // a provider file reference (Gemini Files API `fileUri`, etc.)
    }

    public let kind: Kind
    public let mimeType: String
    public let payload: Payload
    /// The original local path, kept only for display/logging (never sent to a provider).
    public let sourcePath: String?

    public init(kind: Kind, mimeType: String, payload: Payload, sourcePath: String? = nil) {
        self.kind = kind
        self.mimeType = mimeType
        self.payload = payload
        self.sourcePath = sourcePath
    }

    /// Inline bytes, if this attachment carries them (nil for a file-reference payload).
    public var inlineData: Data? {
        if case .inline(let data) = payload { return data }
        return nil
    }

    /// The provider file reference, if this attachment is one (nil for inline bytes).
    public var fileURI: String? {
        if case .fileURI(let uri) = payload { return uri }
        return nil
    }

    /// Approximate request weight in bytes (inline only; a file reference is ~free in-request).
    public var inlineByteCount: Int { inlineData?.count ?? 0 }
}

public extension MediaAttachment {
    /// Map a file extension to a `(kind, mimeType)` we know how to send. Returns nil for anything
    /// not a recognized media type — the resolver leaves those tokens in the prompt as plain text.
    /// Lowercase the extension before calling.
    static func kindAndMime(forExtension ext: String) -> (Kind, String)? {
        switch ext {
        // images
        case "png":  return (.image, "image/png")
        case "jpg", "jpeg": return (.image, "image/jpeg")
        case "gif":  return (.image, "image/gif")
        case "webp": return (.image, "image/webp")
        case "heic": return (.image, "image/heic")
        case "bmp":  return (.image, "image/bmp")
        // video
        case "mp4":  return (.video, "video/mp4")
        case "mov":  return (.video, "video/quicktime")
        case "webm": return (.video, "video/webm")
        case "avi":  return (.video, "video/x-msvideo")
        case "mpeg", "mpg": return (.video, "video/mpeg")
        case "3gp":  return (.video, "video/3gpp")
        case "wmv":  return (.video, "video/x-ms-wmv")
        case "flv":  return (.video, "video/x-flv")
        // audio
        case "mp3":  return (.audio, "audio/mpeg")
        case "wav":  return (.audio, "audio/wav")
        case "aac":  return (.audio, "audio/aac")
        case "ogg":  return (.audio, "audio/ogg")
        case "flac": return (.audio, "audio/flac")
        case "m4a":  return (.audio, "audio/mp4")
        case "aiff", "aif": return (.audio, "audio/aiff")
        // documents
        case "pdf":  return (.pdf, "application/pdf")
        default: return nil
        }
    }
}
