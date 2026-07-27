import Foundation
import AgentCore
#if canImport(AppKit)
import AppKit
#endif

/// Pulls an image off the system clipboard as a media attachment — the Cmd-Shift-4-then-paste path
/// (and copied image files). macOS-only; a no-op elsewhere so the `/paste` command still compiles.
enum PasteboardReader {
    static func text() -> String? {
        #if canImport(AppKit)
        return NSPasteboard.general.string(forType: .string)
        #else
        return nil
        #endif
    }

    static func imageAttachment() -> MediaAttachment? {
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        // 1. Raw image bytes on the clipboard (screenshots, copied images).
        if let png = pb.data(forType: .png) {
            return MediaAttachment(kind: .image, mimeType: "image/png", payload: .inline(png), sourcePath: "clipboard")
        }
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return MediaAttachment(kind: .image, mimeType: "image/png", payload: .inline(png), sourcePath: "clipboard")
        }
        // 2. A copied media FILE (Finder "Copy") — read the first recognized media url.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                let ext = url.pathExtension.lowercased()
                if let (kind, mime) = MediaAttachment.kindAndMime(forExtension: ext),
                   let data = try? Data(contentsOf: url) {
                    return MediaAttachment(kind: kind, mimeType: mime, payload: .inline(data), sourcePath: url.path)
                }
            }
        }
        #endif
        return nil
    }
}
