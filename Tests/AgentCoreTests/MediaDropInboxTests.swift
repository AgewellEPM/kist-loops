import XCTest
import Foundation
@testable import AgentCore

/// macOS drag/screenshot inbox (`<$TMPDIR>/TemporaryItems/…`) — the fix for the 2026-08-04 error
/// where `view_image` refused a dragged screenshot at
/// `/var/folders/…/T/TemporaryItems/NSIRD_screencaptureui_XXXX/Screenshot.png` ("escapes the project
/// root"), forcing the agent into an irreversible `cp` workaround just to look at a file the user
/// had already handed it.
///
/// MULTI-SITE DISCIPLINE: read resolution lives at TWO sibling entry points that must agree —
/// `resolvedPathForReading` (view_image VALIDATES here) and `confinedRootForReading` (view_image
/// READS BYTES there). A fix in one without the other passes validation and then fails the read.
/// Each site gets its OWN assertion. Writes must stay project-confined — asserted too. Precision
/// (only `TemporaryItems`, not all of $TMPDIR) is pinned so we don't silently widen the read surface.
final class MediaDropInboxTests: XCTestCase {

    private var project: String!     // the confinement root
    private var inboxFile: String!   // a file the user "attached" — under the real OS inbox
    private var inboxDir: String!    // our unique subdir under <$TMPDIR>/TemporaryItems to clean up
    private var siblingFile: String! // under $TMPDIR but OUTSIDE TemporaryItems — must stay refused
    private var siblingDir: String!

    override func setUpWithError() throws {
        project = ToolContext.canonicalize(
            try makeDir(NSTemporaryDirectory() + "mediadrop-project-\(UUID().uuidString)"))!

        // Stage a file under the ACTUAL macOS inbox the same way a screenshot lands there, so the
        // live `mediaDropInbox()` computation (real NSTemporaryDirectory) actually resolves it.
        let inboxRoot = (NSTemporaryDirectory() as NSString).appendingPathComponent("TemporaryItems")
        inboxDir = (inboxRoot as NSString).appendingPathComponent("kisttest-\(UUID().uuidString)")
        _ = try makeDir(inboxDir)
        inboxFile = (inboxDir as NSString).appendingPathComponent("Screenshot.png")
        try Self.onePixelPNG.write(to: URL(fileURLWithPath: inboxFile))

        // A sibling under $TMPDIR but NOT under TemporaryItems — proves we didn't open all of $TMPDIR.
        siblingDir = ToolContext.canonicalize(
            try makeDir(NSTemporaryDirectory() + "mediadrop-sibling-\(UUID().uuidString)"))!
        siblingFile = (siblingDir as NSString).appendingPathComponent("secret.png")
        try Self.onePixelPNG.write(to: URL(fileURLWithPath: siblingFile))
    }

    override func tearDownWithError() throws {
        for p in [project, inboxDir, siblingDir] { if let p { try? FileManager.default.removeItem(atPath: p) } }
    }

    private func makeDir(_ p: String) throws -> String {
        try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    /// The inbox grant is AUTOMATIC — a plain project context (no --allow-read) must honor it.
    private func plainContext() -> ToolContext { ToolContext(projectRoot: project) }

    // MARK: - Site 1: resolvedPathForReading (view_image VALIDATES here)

    func testResolvedPathForReadingAcceptsInboxFile() throws {
        let resolved = try plainContext().resolvedPathForReading(inboxFile, mustExist: true)
        XCTAssertEqual(ToolContext.canonicalize(resolved), ToolContext.canonicalize(inboxFile))
    }

    // MARK: - Site 2: confinedRootForReading / readDataForReading (view_image READS BYTES here)

    func testConfinedRootForReadingReadsInboxBytesReadOnly() throws {
        let (root, path) = try plainContext().confinedRootForReading(inboxFile)
        XCTAssertTrue(root.readOnly, "the drag/screenshot inbox must come back READ-ONLY")
        XCTAssertEqual(try root.readData(path), Self.onePixelPNG, "must read the exact attached bytes")
        // And the TOCTOU-safe convenience the tool actually calls:
        XCTAssertEqual(try plainContext().readDataForReading(inboxFile), Self.onePixelPNG)
    }

    // MARK: - End-to-end: the tool that failed in the wild

    func testViewImageToolReadsInboxScreenshotEndToEnd() async throws {
        let tool = ViewImageTool(analyze: { attachment, _ in
            guard case .inline(let data) = attachment.payload else { return "no-bytes" }
            return "saw \(data.count) bytes"
        })
        let result = try await tool.execute(arguments: ["path": inboxFile!], context: plainContext())
        XCTAssertTrue(result.success, "view_image must NOT refuse a user-attached screenshot: \(result.error ?? "")")
        XCTAssertTrue(result.output.contains("saw \(Self.onePixelPNG.count) bytes"), result.output)
    }

    // MARK: - Writes stay project-confined (the inbox is READ-only, never a write target)

    func testInboxIsNotWritable() {
        // Write tools validate via `resolvedPath` (NOT ...ForReading): the inbox must still escape.
        XCTAssertThrowsError(try plainContext().resolvedPath(inboxFile, mustExist: true)) { error in
            XCTAssertTrue("\(error)".contains("escapes the project root"), "\(error)")
        }
        // And even the read-only handle refuses mutation at the primitive level.
        let (root, path) = try! plainContext().confinedRootForReading(inboxFile)
        XCTAssertThrowsError(try root.writeString(path, "x", createParents: false)) { error in
            XCTAssertTrue("\(error)".contains("READ-ONLY"), "\(error)")
        }
    }

    // MARK: - Precision: only TemporaryItems is auto-armed, not the whole $TMPDIR

    func testSiblingTmpPathOutsideInboxStillRefused() {
        XCTAssertThrowsError(try plainContext().confinedRootForReading(siblingFile)) { error in
            XCTAssertTrue("\(error)".contains("escapes the project root"),
                          "a $TMPDIR path OUTSIDE TemporaryItems must NOT be readable: \(error)")
        }
        XCTAssertThrowsError(try plainContext().resolvedPathForReading(siblingFile, mustExist: true))
    }

    // MARK: - The inbox path is named in the honest error (steers the model, not a dead end)

    func testEscapeErrorNamesTheInboxAsReadable() {
        XCTAssertThrowsError(try plainContext().confinedRootForReading(siblingFile)) { error in
            let inbox = ToolContext.mediaDropInbox() ?? "<none>"
            XCTAssertTrue("\(error)".contains(inbox), "error must name the readable inbox: \(error)")
        }
    }

    /// Smallest valid PNG (1×1). Bytes-in == bytes-out is what the read assertions pin.
    private static let onePixelPNG = Data([
        0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A, 0x00,0x00,0x00,0x0D,0x49,0x48,0x44,0x52,
        0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01, 0x08,0x06,0x00,0x00,0x00,0x1F,0x15,0xC4,
        0x89,0x00,0x00,0x00,0x0D,0x49,0x44,0x41, 0x54,0x78,0x9C,0x62,0x00,0x01,0x00,0x00,
        0x05,0x00,0x01,0x0D,0x0A,0x2D,0xB4,0x00, 0x00,0x00,0x00,0x49,0x45,0x4E,0x44,0xAE,
        0x42,0x60,0x82,
    ])
}
