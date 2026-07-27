import XCTest
import AgentCore
@testable import Kist

final class MediaResolverTests: XCTestCase {

    // MARK: tokenizer (the shell-lite splitter dragged paths arrive through)

    func testTokenizePlainWords() {
        XCTAssertEqual(MediaResolver.tokenize("look at this image"), ["look", "at", "this", "image"])
        XCTAssertEqual(MediaResolver.tokenize("   spaced   out  "), ["spaced", "out"])
        XCTAssertEqual(MediaResolver.tokenize(""), [])
    }

    func testTokenizeHonorsQuotesAndEscapes() {
        // single-quoted path with spaces (Terminal.app drag style)
        XCTAssertEqual(MediaResolver.tokenize("see '/Users/me/My Photo.png' now"),
                       ["see", "/Users/me/My Photo.png", "now"])
        // backslash-escaped spaces (other terminals' drag style)
        XCTAssertEqual(MediaResolver.tokenize("/Users/me/My\\ Photo.png"),
                       ["/Users/me/My Photo.png"])
        // double quotes with an inner escape
        XCTAssertEqual(MediaResolver.tokenize("\"a b\" c"), ["a b", "c"])
    }

    // MARK: classify

    func testClassifyKnownAndUnknownExtensions() throws {
        let dir = NSTemporaryDirectory()
        let img = (dir as NSString).appendingPathComponent("mr_test_\(UUID().uuidString).png")
        try Data([0x89, 0x50]).write(to: URL(fileURLWithPath: img))
        defer { try? FileManager.default.removeItem(atPath: img) }

        let hit = MediaResolver.classify(img, projectRoot: dir)
        XCTAssertEqual(hit?.0, .image)
        XCTAssertEqual(hit?.1, "image/png")

        // @-prefixed explicit ref resolves the same file
        XCTAssertEqual(MediaResolver.classify("@" + img, projectRoot: dir)?.0, .image)
        // existing file but non-media extension → nil
        XCTAssertNil(MediaResolver.classify("/etc/hosts", projectRoot: dir))
        // media extension but file doesn't exist → nil
        XCTAssertNil(MediaResolver.classify("/no/such/clip.mp4", projectRoot: dir))
        // a plain word → nil
        XCTAssertNil(MediaResolver.classify("hello", projectRoot: dir))
    }

    func testKindAndMimeCoversImageVideoAudioPdf() {
        XCTAssertEqual(MediaAttachment.kindAndMime(forExtension: "mp4")?.0, .video)
        XCTAssertEqual(MediaAttachment.kindAndMime(forExtension: "mov")?.1, "video/quicktime")
        XCTAssertEqual(MediaAttachment.kindAndMime(forExtension: "mp3")?.0, .audio)
        XCTAssertEqual(MediaAttachment.kindAndMime(forExtension: "pdf")?.0, .pdf)
        XCTAssertNil(MediaAttachment.kindAndMime(forExtension: "txt"))
    }

    // MARK: resolve (lift media out of the line; strip from prompt; note it)

    func testResolveAttachesImageAndStripsPathFromPrompt() throws {
        let dir = NSTemporaryDirectory()
        let img = (dir as NSString).appendingPathComponent("mr_img_\(UUID().uuidString).jpg")
        let bytes = Data(repeating: 0xAB, count: 1024)
        try bytes.write(to: URL(fileURLWithPath: img))
        defer { try? FileManager.default.removeItem(atPath: img) }

        let r = MediaResolver.resolve("what is in '\(img)' exactly", projectRoot: dir)
        XCTAssertEqual(r.prompt, "what is in exactly")
        XCTAssertEqual(r.attachments.count, 1)
        XCTAssertEqual(r.attachments.first?.kind, .image)
        XCTAssertEqual(r.attachments.first?.mimeType, "image/jpeg")
        XCTAssertEqual(r.attachments.first?.inlineData, bytes)
        XCTAssertTrue(r.notes.contains { $0.contains("attached image") })
    }

    func testResolveDeduplicatesRepeatedDraggedMediaPaths() throws {
        let dir = NSTemporaryDirectory()
        let img = (dir as NSString).appendingPathComponent("mr_dup_\(UUID().uuidString).png")
        let bytes = Data(repeating: 0xCD, count: 128)
        try bytes.write(to: URL(fileURLWithPath: img))
        defer { try? FileManager.default.removeItem(atPath: img) }

        let input = "what is this \(img) \(img) \(img) please"
        let r = MediaResolver.resolve(input, projectRoot: dir)

        XCTAssertEqual(r.prompt, "what is this please")
        XCTAssertEqual(r.attachments.count, 1)
        XCTAssertEqual(r.notes.filter { $0.contains("attached image") }.count, 1)
    }

    func testResolveAttachesPdfAndVideoAndStripsBothPaths() throws {
        let dir = NSTemporaryDirectory()
        let pdf = (dir as NSString).appendingPathComponent("mr_doc_\(UUID().uuidString).pdf")
        let vid = (dir as NSString).appendingPathComponent("mr_clip_\(UUID().uuidString).mp4")
        try Data([0x25, 0x50, 0x44, 0x46]).write(to: URL(fileURLWithPath: pdf))
        try Data([0x00, 0x00, 0x00, 0x18]).write(to: URL(fileURLWithPath: vid))
        defer {
            try? FileManager.default.removeItem(atPath: pdf)
            try? FileManager.default.removeItem(atPath: vid)
        }

        let r = MediaResolver.resolve("inspect '\(pdf)' \(vid) now", projectRoot: dir)

        XCTAssertEqual(r.prompt, "inspect now")
        XCTAssertEqual(r.attachments.map(\.kind), [.pdf, .video])
        XCTAssertEqual(r.attachments.map(\.mimeType), ["application/pdf", "video/mp4"])
        XCTAssertTrue(r.uploads.isEmpty)
        XCTAssertTrue(r.notes.contains { $0.contains("attached pdf") })
        XCTAssertTrue(r.notes.contains { $0.contains("attached video") })
    }

    func testResolveQueuesOversizeForUploadAndStripsPath() throws {
        // classify needs the file to exist; report it oversize via the injected fileSize so we don't
        // need a real 20MB+ file on disk.
        let dir = NSTemporaryDirectory()
        let vid = (dir as NSString).appendingPathComponent("mr_big_\(UUID().uuidString).mp4")
        try Data([0x00]).write(to: URL(fileURLWithPath: vid))
        defer { try? FileManager.default.removeItem(atPath: vid) }

        let r = MediaResolver.resolve("describe \(vid)", projectRoot: dir,
                                      fileSize: { _ in MediaResolver.inlineCapBytes + 1 })
        XCTAssertTrue(r.attachments.isEmpty)
        XCTAssertEqual(r.prompt, "describe")                       // path lifted out, not dumped as text
        XCTAssertEqual(r.uploads.count, 1)
        XCTAssertEqual(r.uploads.first?.kind, .video)
        XCTAssertEqual(r.uploads.first?.mimeType, "video/mp4")
        XCTAssertTrue(r.notes.contains { $0.contains("queued") })
    }

    func testResolveUnreadableSmallFileLeftAsText() {
        let dir = NSTemporaryDirectory()
        let img = (dir as NSString).appendingPathComponent("mr_unreadable_\(UUID().uuidString).png")
        try? Data([0x89]).write(to: URL(fileURLWithPath: img))
        defer { try? FileManager.default.removeItem(atPath: img) }
        // size says small, but the read fails → keep the token as text, don't fabricate an attachment.
        let r = MediaResolver.resolve("see \(img)", projectRoot: dir,
                                      fileSize: { _ in 10 }, read: { _ in nil })
        XCTAssertTrue(r.attachments.isEmpty)
        XCTAssertTrue(r.uploads.isEmpty)
        XCTAssertTrue(r.prompt.contains(img))
    }

    func testResolveLeavesPlainTextUntouched() {
        let r = MediaResolver.resolve("just a normal question", projectRoot: NSTemporaryDirectory())
        XCTAssertTrue(r.attachments.isEmpty)
        XCTAssertTrue(r.notes.isEmpty)
        XCTAssertEqual(r.prompt, "just a normal question")
    }
}
